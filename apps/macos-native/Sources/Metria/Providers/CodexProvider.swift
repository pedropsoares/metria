import Foundation
import MetriaCore

/// Fetches Codex usage from the native Codex CLI credentials, falling back to local
/// Codex CLI session files when those credentials are missing.
struct CodexProvider: UsageProvider {
    let kind = ProviderKind.codex
    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: codexAuthURL.path) || FileManager.default.fileExists(atPath: sessionsURL.path)
    }
    let setupHint = "Sign in to Codex to create local usage data."

    private var codexAuthURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json") }
    private var sessionsURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions") }

    func fetch() async -> ProviderFetchResult {
        if let remoteResult = await fetchCodexUsage() {
            switch remoteResult {
            case .loaded(_), .empty(_):
                return remoteResult
            case .failed(_, let message, let retryAfter):
                if case .loaded(var localUsage) = fetchLocalUsage() {
                    localUsage.error = "\(message) Showing the latest local session data."
                    return .loaded(localUsage)
                }
                return .failed(kind, message, retryAfter: retryAfter)
            }
        }
        return fetchLocalUsage()
    }
    private func fetchCodexUsage() async -> ProviderFetchResult? {
        guard let data = try? Data(contentsOf: codexAuthURL) else { return nil }
        guard let credentials = try? JSONDecoder().decode(CodexAuth.self, from: data).tokens else { return nil }
        guard let accountId = credentials.accountId else { return nil }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("Metria/0.1", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                let error = ProviderError.http(status)
                return .failed(kind, error.localizedDescription, retryAfter: error.retryAfter)
            }
            let value = try JSONDecoder().decode(OpenAIUsageResponse.self, from: data)
            return .loaded(ProviderUsage(kind: kind, windows: [
                UsageWindow(title: "Current session", percent: value.rateLimit.primaryWindow.usedPercent, resetDate: Date(timeIntervalSince1970: Double(value.rateLimit.primaryWindow.resetAt))),
                UsageWindow(title: "All models", percent: value.rateLimit.secondaryWindow.usedPercent, resetDate: Date(timeIntervalSince1970: Double(value.rateLimit.secondaryWindow.resetAt)))
            ], updatedAt: Date(), error: nil))
        } catch {
            let providerError = error as? ProviderError
            return .failed(kind, error.localizedDescription, retryAfter: providerError?.retryAfter)
        }
    }
    private func fetchLocalUsage() -> ProviderFetchResult {
        let candidates = findCandidates()
        for candidate in candidates.sorted(by: { $0.0 > $1.0 }) {
            guard let text = try? String(contentsOf: candidate.1, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n").reversed()
            for line in lines {
                guard line.contains("rate_limits"), let data = line.data(using: .utf8), let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let payload = event["payload"] as? [String: Any] else { continue }
                let limits = (payload["rate_limits"] as? [String: Any]) ?? ((payload["info"] as? [String: Any])?["rate_limits"] as? [String: Any])
                guard let limits else { continue }
                let primary = parseLimit(limits["primary"] as? [String: Any], title: "Current session")
                let secondary = parseLimit(limits["secondary"] as? [String: Any], title: "All models")
                return .loaded(ProviderUsage(kind: kind, windows: [primary, secondary].compactMap { $0 }, updatedAt: candidate.0, error: nil))
            }
        }
        return .empty(ProviderUsage(kind: kind, windows: [], updatedAt: nil, error: "No recent local usage data was found. Sign in and use Codex once to create a usage snapshot."))
    }
    private struct CodexAuth: Decodable {
        let tokens: Tokens?

        struct Tokens: Decodable {
            let accessToken: String
            let accountId: String?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case accountId = "account_id"
            }
        }
    }
    private struct OpenAIUsageResponse: Decodable {
        let rateLimit: RateLimit
        enum CodingKeys: String, CodingKey { case rateLimit = "rate_limit" }
        struct RateLimit: Decodable { let primaryWindow: Window; let secondaryWindow: Window; enum CodingKeys: String, CodingKey { case primaryWindow = "primary_window"; case secondaryWindow = "secondary_window" } }
        struct Window: Decodable { let usedPercent: Double; let resetAt: Int; enum CodingKeys: String, CodingKey { case usedPercent = "used_percent"; case resetAt = "reset_at" } }
    }
    private func findCandidates() -> [(Date, URL)] {
        let fileManager = FileManager.default
        let root = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var candidates: [(Date, URL)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil { candidates.append((date, url)) }
        }
        return candidates
    }
    private func parseLimit(_ raw: [String: Any]?, title: String) -> UsageWindow? {
        guard let raw, let rawPercent = raw["used_percent"] as? NSNumber else { return nil }
        let percent = rawPercent.doubleValue
        let reset = (raw["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return UsageWindow(title: title, percent: reset.map { $0 < Date() ? 0 : percent } ?? percent, resetDate: reset)
    }
}
