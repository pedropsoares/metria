import Foundation
import MetriaCore

/// Fetches Claude usage using the OAuth token Claude Code stores in the macOS Keychain.
struct ClaudeProvider: UsageProvider {
    let kind = ProviderKind.claude
    var isAvailable: Bool { KeychainReader.hasClaudeCredentials }
    let setupHint = "Install Claude Code and sign in to make usage available."
    func fetch() async -> ProviderFetchResult {
        do {
            let token = try await KeychainReader.readClaudeToken()
            let data = try await requestUsage(token: token)
            let value = try JSONDecoder().decode(ClaudeResponse.self, from: data)
            return .loaded(ProviderUsage(kind: kind, windows: [
                UsageWindow(title: "Current session", percent: value.fiveHour.utilization, resetDate: value.fiveHour.resetDate),
                UsageWindow(title: "All models", percent: value.sevenDay.utilization, resetDate: value.sevenDay.resetDate)
            ], updatedAt: Date(), error: nil))
        } catch {
            let providerError = error as? ProviderError
            FileHandle.standardError.write("[Claude] error: \(error.localizedDescription)\n".data(using: .utf8)!)
            return .failed(kind, error.localizedDescription, retryAfter: providerError?.retryAfter)
        }
    }
    private func requestUsage(token: String) async throws -> Data {
        for attempt in 0..<3 {
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("Metria/0.1", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            let status = httpResponse?.statusCode ?? -1
            guard status == 429 else {
                guard status == 200 else { throw ProviderError.http(status) }
                return data
            }
            let retryAfter = httpResponse?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? pow(2, Double(attempt + 1))
            guard attempt < 2 else { throw ProviderError.rateLimited(retryAfter: retryAfter) }
            try await Task.sleep(for: .seconds(min(retryAfter, 30)))
        }
        throw ProviderError.unavailable
    }
    private struct ClaudeResponse: Decodable {
        let fiveHour: Limit
        let sevenDay: Limit
        enum CodingKeys: String, CodingKey { case fiveHour = "five_hour"; case sevenDay = "seven_day" }
        struct Limit: Decodable {
            let utilization: Double
            let resetsAt: String?
            var resetDate: Date? {
                guard let resetsAt else { return nil }
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return formatter.date(from: resetsAt) ?? {
                    formatter.formatOptions = [.withInternetDateTime]
                    return formatter.date(from: resetsAt)
                }()
            }
            enum CodingKeys: String, CodingKey { case utilization; case resetsAt = "resets_at" }
        }
    }
}
